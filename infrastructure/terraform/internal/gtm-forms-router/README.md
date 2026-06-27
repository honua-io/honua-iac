# GTM forms router (honua.io leads → Attio)

Internal (non-operator) stack: a single Node.js Lambda behind a public Lambda
Function URL that receives honua.io form submissions and routes them into the
Attio CRM. It is completely independent of the operator example stacks — it
has its own root and its own local state.

## Endpoints

`POST <function_url>contact` — migration-assessment contact form. Upserts the
Person (by email) and Company (by email domain, skipping freemail domains),
then stores the site's `lead_*` attribution fields and message as a note on
the Person.

`POST <function_url>waitlist` — Honua Cloud waitlist. Upserts Person/Company
and asserts a "Cloud Waitlist" list entry (optional `workload_signal` /
`source_stack` entry values when present in the payload).

`POST <function_url>newsletter` — newsletter signups. Upserts the Person and
asserts a "Newsletter" list entry.

Accepted bodies: JSON, form-encoded, and FormSubmit `_webhook` payloads
(`{"form_data": {...}}`). A `form_type` field is honoured when the path does
not disambiguate. Requests with a non-empty honeypot field (`_honey`,
`_gotcha`, `honeypot`) are accepted with `200` and silently dropped. Email is
required and syntactically validated; bodies over 32 KiB are rejected.

When a real Loops.so API key is set in the Loops secret (Terraform manages a
`REPLACE_ME` placeholder by default, which disables the path), waitlist/newsletter
emails are also subscribed to Loops. The key is read from Secrets Manager at
runtime (`LOOPS_SECRET_ARN`), never injected as a plaintext env var.

CORS allows `https://honua.io` only (POST). Reserved concurrency is 10.

## Deploy

```bash
terraform -chdir=infrastructure/terraform/internal/gtm-forms-router init
terraform -chdir=infrastructure/terraform/internal/gtm-forms-router apply
```

Then set the real Attio API key **out of band** (Terraform only manages a
`REPLACE_ME` placeholder and ignores value drift — never commit or echo the
key):

```bash
aws secretsmanager put-secret-value \
  --secret-id honua/gtm/attio-api-key \
  --secret-string file:///path/to/attio.key

# Optional: enable the Loops.so subscription path the same way.
aws secretsmanager put-secret-value \
  --secret-id honua/gtm/loops-api-key \
  --secret-string file:///path/to/loops.key
```

The Lambda caches each key per execution environment; after rotating a
secret, either wait for environments to recycle or update any Lambda
configuration value to force a refresh.

## State

State is local to this root (`terraform.tfstate`, gitignored). Do not point
this root at the state of any other stack.
