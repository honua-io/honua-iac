# Shared-account content-read controls

`DenyNonGateContentReads` applies to both generated service and workload policies
only in shared-account mode. It denies the actions below unless AWS supplies
`aws:ResourceTag/aws:cloudformation:stack-name` matching `honua-gate-*`.
A missing key denies the request, including requests for a gate resource.
Unsupported APIs require a reviewed policy adjustment, not a blanket exception.

The list is conservative: wildcard families can include metadata operations.
This is an offline policy audit against the linked AWS service authorization
references. It does not establish live tag propagation or an AWS authorization pass.

## acm

[acm authorization reference](https://docs.aws.amazon.com/service-authorization/latest/reference/list_acm.html)

Certificates, exported private keys and ACME credentials. These actions expose resource tags.

Actions: `acm:GetCertificate`, `acm:ExportCertificate`, `acm:GetAcmeExternalAccountBindingCredentials`.

## backup

[backup authorization reference](https://docs.aws.amazon.com/service-authorization/latest/reference/list_backup.html)

Restore metadata and recovery-point access; restore/copy operations also require ownership. Recovery-point APIs support tags; GetRestoreJobMetadata and GetRestoreTestingInferredMetadata do not expose this ownership key.

Actions: `backup:GetRecoveryPoint*`, `backup:GetRestore*`, `backup:DescribeRecoveryPoint`, `backup:StartRestoreJob`, `backup:StartCopyJob`, `backup:Copy*`.

## batch

[batch authorization reference](https://docs.aws.amazon.com/service-authorization/latest/reference/list_batch.html)

Job definitions and jobs can contain commands and environment values. DescribeJobDefinitions, DescribeJobs and DescribeServiceJob have no resource-tag condition.

Actions: `batch:DescribeJobs`, `batch:DescribeJobD*` (exactly DescribeJobDefinitions), `batch:DescribeServiceJob`.
DescribeJobQueues returns queue metadata only and is not a content read; the job queue handler needs it.
Exception (service role only): CloudFormation may call `batch:DescribeJobD*` to manage the job definitions it registers. The API has no resource scope, so this role can read every job definition in the account, as it already can for ECS task definitions.
Exception (workload boundary only): a gate server polls its Batch jobs with `batch:DescribeJobs` and cancels them with `batch:TerminateJob`. DescribeJobs has no resource scope, so a gate workload can read the details of any Batch job in the shared account; only gate stacks submit jobs there, and job definitions carry secret references, not values. TerminateJob is limited to jobs tagged `honua:stack` with a gate stack name; the template requires that tag at submit and the boundary cannot tag another stack's job. The lane keeps the fence, and job definitions and service jobs stay fenced for workloads.

## cloudfront

[cloudfront authorization reference](https://docs.aws.amazon.com/service-authorization/latest/reference/list_cloudfront.html)

Function code, distribution origin headers, custom response headers, keys and field-level encryption. Get* and List* deliberately also restrict metadata to keep the managed policy within its size quota. Distribution/function reads support tags; key/FLE/policy reads and the listed account-wide list APIs do not.

Actions: `cloudfront:Get*`, `cloudfront:List*`.

## ec2

[ec2 authorization reference](https://docs.aws.amazon.com/service-authorization/latest/reference/list_ec2.html)

Console output/screenshots, passwords, launch-template/user-data, UEFI data, public keys and VPN configuration. Instance reads support tags; DescribeLaunchTemplateVersions and DescribeVpnConnections and DescribeKeyPairs cannot use this ownership key.

Actions: `ec2:GetPasswordData`, `ec2:GetConsole*`, `ec2:GetLaunchTemplateData`, `ec2:GetInstanceUefiData`, `ec2:GetVpnConnectionDeviceSampleConfiguration`, `ec2:DescribeInstanceAttribute`, `ec2:DescribeKeyPairs`, `ec2:DescribeLaunchTemplateVersions`, `ec2:DescribeVpnConnections`.

## ecs

[ecs authorization reference](https://docs.aws.amazon.com/service-authorization/latest/reference/list_ecs.html)

Interactive command execution, task definitions and task/service/daemon revisions can expose commands and environment values. Tasks support tags; DescribeTaskDefinition has no resource-tag condition.

Actions: `ecs:ExecuteCommand`, `ecs:DescribeTask*`, `ecs:DescribeServiceRevisions`, `ecs:DescribeDaemon*`.

## elasticloadbalancing

[ELB V2 authorization reference](https://docs.aws.amazon.com/service-authorization/latest/reference/list_elbv2.html) and [classic ELB reference](https://docs.aws.amazon.com/service-authorization/latest/reference/list_elb.html)

Trust-store certificate/revocation contents and listener/rule content, including fixed responses, plus classic load-balancer policy public keys. Trust-store reads support tags; DescribeListeners, DescribeRules and DescribeLoadBalancerPolicies do not expose this ownership key.

Actions: `elasticloadbalancing:GetTrustStore*`, `elasticloadbalancing:DescribeRules`, `elasticloadbalancing:DescribeListeners`, `elasticloadbalancing:DescribeLoadBalancerPolicies`.

## ecr

[ecr authorization reference](https://docs.aws.amazon.com/service-authorization/latest/reference/list_ecr.html)

Registry credentials and image manifests/layers. Repository content reads support tags; GetAuthorizationToken has no resource-tag condition.

Actions: `ecr:GetAuthorizationToken`, `ecr:BatchGetImage`, `ecr:GetDownloadUrlForLayer`.

Exception (workload boundary only): the ownership fence exempts registry login and the
Terraform-owned `honua-gate/server` repository, which has no stack tag, so gate stacks can
pull the private gate server image. A registry token reads nothing by itself; image reads
from every other repository still require gate stack ownership. The service role keeps the
full fence.

## lambda

[lambda authorization reference](https://docs.aws.amazon.com/service-authorization/latest/reference/list_lambda.html)

Function/layer code, environment variables and execution data. Get* deliberately also restricts metadata. Function reads support tags; GetLayerVersion and account-wide ListFunctions do not expose this ownership key. List APIs returning function configurations and stored event-filter patterns are included. ListEventSourceMappings has no resource-tag condition. The broad Get*/List* patterns also restrict metadata and keep the managed policy within its size quota.

Actions: `lambda:Get*`, `lambda:List*`.

## logs

[logs authorization reference](https://docs.aws.amazon.com/service-authorization/latest/reference/list_logs.html)

Event contents, query results, samples, anomaly records, lookup tables, transformer constants and saved query text. Get* also restricts metadata to keep the managed policy within its size quota. Log-group reads support tags; DescribeAccountPolicies, DescribeQueries and DescribeQueryDefinitions have no resource-tag condition.

Actions: `logs:Get*`, `logs:FilterLogEvents`, `logs:StartQuery`, `logs:StartLiveTail`, `logs:ListAnomalies`, `logs:DescribeAccountPolicies`, `logs:DescribeQueries`, `logs:DescribeQueryDefinitions`, `logs:ListScheduledQueries`.

## rds

[rds authorization reference](https://docs.aws.amazon.com/service-authorization/latest/reference/list_rds.html)

Database log contents, stored proxy initialization SQL (DescribeDBProxyTargetGroups), and data-bearing copy/restore/export operations. Proxy target-group reads support resource tags. Source resource authorization must expose the ownership tag. The separate rds-data and rds-db namespaces have no Allow.

Actions: `rds:DescribeDBProxyTargetGroups`, `rds:Download*`, `rds:Copy*`, `rds:Restore*`, `rds:StartExportTask`.

## route53

[route53 authorization reference](https://docs.aws.amazon.com/service-authorization/latest/reference/list_route53.html)

TXT/other record contents and stored traffic-policy documents. These APIs do not expose the ownership key.

Actions: `route53:ListResourceRecordSets`, `route53:GetTrafficPolicy`, `route53:ListTrafficPolicyVersions`.

## secretsmanager

[secretsmanager authorization reference](https://docs.aws.amazon.com/service-authorization/latest/reference/list_secretsmanager.html)

Secret values. GetSecretValue supports resource tags; BatchGetSecretValue cannot evaluate this key, so even gate batch reads are denied. Use per-secret GetSecretValue.

Actions: `secretsmanager:GetSecretValue`, `secretsmanager:BatchGetSecretValue`.

## wafv2

[wafv2 authorization reference](https://docs.aws.amazon.com/service-authorization/latest/reference/list_wafv2.html)

Decrypted API keys, sampled HTTP request contents, and Web ACL custom response bodies and literal headers. Get* deliberately also restricts metadata. GetWebACL and GetSampledRequests support tags; GetDecryptedAPIKey and ListAPIKeys do not expose this ownership key.

Actions: `wafv2:Get*`, `wafv2:ListAPIKeys`.

## ce

[Cost Explorer authorization reference](https://docs.aws.amazon.com/service-authorization/latest/reference/list_awscostexplorerservice.html)

Account cost, usage, forecast and tag breakdowns. Anomaly-monitor reads stay on the metadata exception so a gate stack can read the monitor it creates. These account-level reads do not expose the ownership key, so the deny applies to gate callers as well.

Actions: `ce:GetCost*`, `ce:GetDimensionValues`, `ce:GetTags`. `ce:GetCost*` also covers usage-with-resources, forecast and cost-category reads.

## cloudtrail

[cloudtrail authorization reference](https://docs.aws.amazon.com/service-authorization/latest/reference/list_awscloudtrail.html)

Event history and query results can include request parameters. LookupEvents has no resource-tag condition. GetQueryResults does not expose this ownership key. Trail configuration reads remain on the metadata exception.

Actions: `cloudtrail:LookupEvents`, `cloudtrail:GetQueryResults`.

These denies do not cover a trail the gate identity creates into a `honua-gate-*` bucket. The Launch Stack's protection trail is that path, and objects in a gate bucket are readable under this boundary. Treat delivered management events as visible to gate workloads.

## cloudwatch

[cloudwatch authorization reference](https://docs.aws.amazon.com/service-authorization/latest/reference/list_amazoncloudwatch.html)

Dashboard bodies. Alarm and metric reads are metadata. GetDashboard supports resource tags.

Actions: `cloudwatch:GetDashboard`.

## guardduty

[guardduty authorization reference](https://docs.aws.amazon.com/service-authorization/latest/reference/list_amazonguardduty.html)

Finding details. Detector reads stay on the metadata exception. GetFindings supports resource tags; the wildcard also covers statistics.

Actions: `guardduty:GetFindings*`.

A gate-named EventBridge rule can still receive GuardDuty finding events. The Launch Stack creates those rules. `GetFindings` is not a control against that delivery.

## kms

[kms authorization reference](https://docs.aws.amazon.com/service-authorization/latest/reference/list_awskeymanagementservice.html)

Plaintext from decrypt and data-key calls, key policies and imported key material. Decrypt, data-key and re-encrypt operations support key tags. GetKeyPolicy supports key tags. GetParametersForImport does not expose this ownership key.

Actions: `kms:Decrypt`, `kms:GenerateDataKey*`, `kms:ReEncrypt*`, `kms:Get*`. `kms:Get*` keeps the managed policy inside its quota and also denies key-policy, public-key and import-parameter reads. Describe and list are not in this deny. The service role still exempts them; the workload boundary does not.

## sns

[sns authorization reference](https://docs.aws.amazon.com/service-authorization/latest/reference/list_amazonsns.html)

SMS settings and opted-out phone numbers. Topic configuration reads stay on the metadata exception. SNS has no API that returns stored notification bodies. These account-level reads do not expose the ownership key.

Actions: `sns:GetSMSAttributes`, `sns:ListPhoneNumbersOptedOut`.

## sqs

[sqs authorization reference](https://docs.aws.amazon.com/service-authorization/latest/reference/list_amazonsqs.html)

Queue messages. ReceiveMessage supports queue tags. Queue attribute reads stay on the metadata exception.

Actions: `sqs:ReceiveMessage`.

## Remaining allowed families

- [Application Auto Scaling](https://docs.aws.amazon.com/service-authorization/latest/reference/list_application-autoscaling.html): read/list/describe APIs expose scaling metadata and forecasts; no stored payload or credential read was identified.
- [IAM](https://docs.aws.amazon.com/service-authorization/latest/reference/list_iam.html): service-role reads are already limited to gate role names; workload IAM permissions remain restricted to PassRole. There is no account-wide credential or policy-content read Allow.
- S3 content is already restricted to the gate bucket prefix, with explicit protected-state denial. SSM is explicitly denied in full. No new exception is added for either.

The mocked tests assert foreign/missing-tag secret denial and preservation of
the single-secret gate-tag allow in both policies. AWS must still verify those
decisions live, including batch and multi-resource behavior, before a gate pass.
