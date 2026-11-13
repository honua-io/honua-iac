# aws-audit

Audit trail for the Honua AWS account: who changed what and when,
and an email when something changes outside IaC.

| Piece | What it does |
|---|---|
| CloudTrail `honua-audit` | One multi-Region trail: management events (read and write), log file validation. Delivered to the audit bucket under `cloudtrail/`. No data events, no Insights. |
| Audit bucket `honua-audit-<account>` | SSE-S3, versioned, public access blocked, ACLs disabled. The policy admits CloudTrail (this trail) and legacy Config deliveries (this account), denies object deletes and plain HTTP. Standard for 90 days, then Glacier Instant Retrieval (objects of 128 KB and up), expired after 365 days. |
| Alerts | EventBridge rules `honua-audit-change-{ec2,identity-storage,services}` (configuration-changing calls not made by Terraform, CloudFormation or an AWS service) and the legacy `honua-audit-stack-drift` listener. eu-north-1 and us-west-2 forward to the us-east-1 bus; SNS `honua-audit-alerts` emails the build host budget address. |
| Budget `honua-audit-monthly` | Emails at 80% actual and 100% forecast of `monthly_budget_usd` (CloudTrail). |
| `/honua/audit/alert-canary` | eu-north-1 parameter for testing the alert path. |

SSE-S3 rather than KMS: the key would cost $1 a month plus a KMS request for every delivered file,
and it buys nothing here. Access is held by the bucket policy, and log file validation detects
tampering. SSM parameter changes are in CloudTrail, and SSM keeps the last 100 versions of
each parameter (`get-parameter-history`).

AWS Config recorders and stack-drift rules are disabled. Existing Config objects remain in the
audit bucket until the retention policy expires them. The legacy Config bucket permissions and
EventBridge listener remain; no Config recorder or rule produces new events.

## Cost (per month)

| Component | Estimate |
|---|---|
| CloudTrail management events | $0 (first copy is free) |
| S3: CloudTrail objects, PUTs, storage | under $1 |
| EventBridge (AWS events and cross-Region forwarding), SNS email | under $0.10 |
| Budget (no budget actions) | under $1 |

## Apply (operator)

Inputs live in SSM SecureString `/honua/audit/tfvars` (eu-north-1), holding only `alert_email`.
The address is the one the build host budget uses; to (re)create the parameter without printing it:

```bash
B="honua-tfstate-$(aws sts get-caller-identity --query Account --output text)"
aws s3 cp "s3://$B/bootstrap/aws-build-host/terraform.tfstate" - \
  | jq -r '.resources[] | select(.type=="aws_budgets_budget") | .instances[0].attributes.notification[0].subscriber_email_addresses[0]' \
  | xargs -I{} printf 'alert_email = "%s"\n' {} > "$HOME/audit.tfvars"
aws ssm put-parameter --region eu-north-1 --name /honua/audit/tfvars --type SecureString \
  --overwrite --value "file://$HOME/audit.tfvars" >/dev/null && shred -u "$HOME/audit.tfvars"
```

Then, from a pushed commit (Terraform 1.10 or later):

```bash
cd infrastructure/terraform/bootstrap/aws-audit
sed "s/REPLACE_WITH_STATE_BUCKET_NAME/$B/" backend.tf.example > backend.tf
aws ssm get-parameter --region eu-north-1 --name /honua/audit/tfvars --with-decryption \
  --query Parameter.Value --output text > "$HOME/audit.tfvars"
terraform init && terraform apply -var-file="$HOME/audit.tfvars"; shred -u "$HOME/audit.tfvars"
```

Confirm the SNS subscription from the email AWS sends, or no alert is delivered. Removing the root
needs a PR that drops the `DenyObjectDeletes` statement first; the bucket is never force-destroyed.

## Drift

- Terraform roots: `.github/workflows/bootstrap-drift-plan.yml` plans the CI-plannable roots nightly
  and opens "Terraform drift: bootstrap roots do not match trunk". The operator roots (this one,
  build host, lane host, light runners) keep inputs in SSM and need reads the CI role lacks, so
  from a clean trunk checkout run `scripts/bootstrap-drift-operator.sh`. It plans each one
  read-only and opens or closes "Terraform drift: operator-applied bootstrap roots do not match
  trunk". Exit 0 means clean, 2 drift, 1 error.
- CloudFormation stacks (Launch Stack hosting, test and qualification stacks, and the demo stack from
  the rc.2 cut) use CloudFormation drift detection, never `terraform plan`. By hand:

  ```bash
  id=$(aws cloudformation detect-stack-drift --region us-east-1 --stack-name honua-launch-stack-hosting --query StackDriftDetectionId --output text)
  aws cloudformation describe-stack-drift-detection-status --region us-east-1 --stack-drift-detection-id "$id"
  aws cloudformation describe-stack-resource-drifts --region us-east-1 --stack-name honua-launch-stack-hosting \
    --stack-resource-drift-status-filters MODIFIED DELETED
  ```

  Change Launch Stack resources only through a change set: `create-change-set`, review it with
  `describe-change-set`, then `execute-change-set`. Never edit a stack's resources directly; that
  creates drift.

## Who changed X, and when

Last 90 days, any Region, no setup (one Region per call; IAM and CloudFront calls are in us-east-1):

```bash
aws cloudtrail lookup-events --region eu-north-1 \
  --lookup-attributes AttributeKey=ResourceName,AttributeValue=<sg-id, role name, bucket, ...> \
  --start-time 2026-11-01T00:00:00Z --query 'Events[].[EventTime,EventName,Username]' --output table
```

`AttributeKey` can also be `EventName`, `Username` or `EventSource`. For anything older than 90
days, or to search across Regions, query the bucket with Athena. Athena bills $5 per TB scanned
(a year of this account's logs is well under 1 GB), and creating the table costs nothing. It is
not created by this root; when needed, in us-east-1:

```sql
CREATE EXTERNAL TABLE cloudtrail (
  eventtime string, eventsource string, eventname string, awsregion string,
  useridentity struct<type:string, arn:string, principalid:string>,
  useragent string, errorcode string, requestparameters string, responseelements string,
  resources array<struct<arn:string, type:string>>
)
PARTITIONED BY (region string, day string)
ROW FORMAT SERDE 'org.apache.hive.hcatalog.data.JsonSerDe'
STORED AS INPUTFORMAT 'com.amazon.emr.cloudtrail.CloudTrailInputFormat'
OUTPUTFORMAT 'org.apache.hadoop.hive.ql.io.HiveIgnoreKeyTextOutputFormat'
LOCATION 's3://<audit-bucket>/cloudtrail/AWSLogs/<account>/CloudTrail/'
TBLPROPERTIES (
  'projection.enabled'='true',
  'projection.region.type'='enum', 'projection.region.values'='us-east-1,eu-north-1,us-west-2',
  'projection.day.type'='date', 'projection.day.format'='yyyy/MM/dd',
  'projection.day.range'='2026/11/01,NOW', 'projection.day.interval'='1', 'projection.day.interval.unit'='DAYS',
  'storage.location.template'='s3://<audit-bucket>/cloudtrail/AWSLogs/<account>/CloudTrail/${region}/${day}'
);

SELECT eventtime, eventname, useridentity.arn, useragent
FROM cloudtrail
WHERE day BETWEEN '2026/11/01' AND '2026/11/30' AND requestparameters LIKE '%sg-0123%'
ORDER BY eventtime;
```

Check a log file's integrity: `aws cloudtrail validate-logs --trail-arn <trail arn> --start-time <t>`.

## Test the alert path

Tag the canary by hand, then let Terraform put it back:

```bash
aws ssm add-tags-to-resource --region eu-north-1 --resource-type Parameter \
  --resource-id /honua/audit/alert-canary --tags Key=AlertTest,Value=1
# expect an email within a few minutes, and `terraform plan` shows the tag as drift
terraform apply -var-file="$HOME/audit.tfvars"
```
