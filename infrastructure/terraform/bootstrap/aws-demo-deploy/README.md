# aws-demo-deploy

The apply role for demo.honua.io (honua-demo-infra#104). honua-demo-infra `.github/workflows/terraform.yml` applies `stacks/aws` on merge to `trunk` with this role, in the protected `demo` GitHub environment. A rollback is then a one-line PR (`lambda_alias_version`) that the workflow applies in minutes, not an AWS CLI call.

## Trust

Built with `components/aws-github-oidc`: the account's existing provider, `cert_permissions_enabled = false`, and one exact subject, `repo:honua-io@217718039/honua-demo-infra@1310514636:environment:demo`. honua-demo-infra issues immutable OIDC subjects (`use_immutable_subject = true`), and validation refuses the name form, which would never match. GitHub puts either the environment or the ref in `sub`, never both. Configure `demo` with:
- **required reviewers**, so every apply is approved by a person;
- a **deployment-branch policy of `trunk` only**.

Branch, `pull_request` and wildcard subjects fail variable validation. Pull-request plans use the plan-only role from `bootstrap/aws-drift-plan`, never this one.

## Permissions (inline policy `demo-apply`)

**Allowed**, scoped to the demo:
- **Reads:** the same control-plane reads as the demo drift role.
- **State:** `demo/aws-demo/terraform.tfstate` and its `.tflock`, nothing else.
- **Lambda:** `lambda:*` on `honua-demo-demo-*` functions and their versions/aliases.
- **ECR:** image pull and the repository policy on `honua-server` (us-west-2). Lambda checks the caller can pull the image.
- **IAM roles:** writes on `role/honua-demo-demo-*`. `AttachRolePolicy` is limited to `AWSLambdaBasicExecutionRole`, `AWSLambdaVPCAccessExecutionRole` and the demo's own `policy/honua-demo-demo-*`. `PassRole` only to Lambda, EC2 and RDS.
- **EC2, RDS, ElastiCache:** all actions, in us-west-2 only.
- **Edge:** API Gateway (us-west-2), CloudFront and ACM.
- **Route 53:** record changes in the `demo.honua.io` zone only. The zone id is looked up by name, not committed.
- **S3:** the `honua-demo-data-*` bucket.
- **Secrets Manager:** `honua-demo-demo/*` and `honua-demo/demo/*`.
- **Other:** Logs and alarms (us-west-2), the `honua-demo-demo-*` place index and budget.

**Denied, whatever else is attached:**
- any region other than us-west-2 and us-east-1;
- `rds:DeleteDBInstance`, `rds:DeleteDBCluster`, `rds:DeleteDBSnapshot`, `s3:DeleteBucket`, `secretsmanager:DeleteSecret`, `ec2:DeleteVpc` and `route53:DeleteHostedZone`. A plan that needs one of these fails at apply and goes through break-glass;
- IAM users, access keys, login profiles, OIDC providers, permissions boundaries and `sts:AssumeRole`;
- any IAM write outside `honua-demo-demo-*`, and any action on a `*-gha` role (this one, the drift roles, the cert role);
- any S3 object other than the demo state, its lock file and the data bucket;
- the operator-owned `honua-demo-demo/operation-key-ring`.

**Residual risk:** inline role policies cannot be constrained by content. A reviewer-approved apply can still give a `honua-demo-demo-*` role broad permissions. The `demo` environment's required reviewers are the control for that.

`tests/policies.tftest.hcl` covers:
- the trust condition;
- every deny;
- IAM writes being scoped to demo names;
- the `AttachRolePolicy` condition;
- the zone scoping;
- `pull_request` subjects being refused.

## Apply (operator)

```sh
cd infrastructure/terraform/bootstrap/aws-demo-deploy
sed 's/REPLACE_WITH_STATE_BUCKET_NAME/honua-tfstate-585192672263/' backend.tf.example > backend.tf
terraform init
terraform plan -out=demo-deploy.tfplan \
  -var oidc_provider_arn=arn:aws:iam::585192672263:oidc-provider/token.actions.githubusercontent.com \
  -var state_bucket_name=honua-tfstate-585192672263
terraform apply demo-deploy.tfplan
```

Expected plan: **2 to add**, the role `honua-demo-infra-deploy-gha` and its inline policy `demo-apply`. Then configure the environment and the variable. Replace `<your-user-id>` with `gh api user -q .id`.

```sh
gh api -X PUT repos/honua-io/honua-demo-infra/environments/demo \
  -F 'deployment_branch_policy[protected_branches]=false' -F 'deployment_branch_policy[custom_branch_policies]=true' \
  -F 'reviewers[][type]=User' -F 'reviewers[][id]=<your-user-id>' -F 'prevent_self_review=false'
gh api -X POST repos/honua-io/honua-demo-infra/environments/demo/deployment-branch-policies -f name=trunk
gh variable set HONUA_DEMO_DEPLOY_ROLE_ARN -R honua-io/honua-demo-infra --env demo \
  --body "$(terraform output -raw role_arn)"
```

This root is listed in `../drift-roots.json`, so the nightly bootstrap drift plan covers it from the first night after the apply.
