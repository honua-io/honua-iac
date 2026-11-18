# AWS ECR publish role (honua-server)

This root owns `honua-server-gha-ecr-publish`, the role that honua-server
`deploy.yml` and `deploy-platform-images.yml` assume to push release and
platform images to Amazon ECR. It does not create the OIDC provider, the
repository or any access key.

## Trust

`sts:AssumeRoleWithWebIdentity` is allowed only for the exact subject
`repo:honua-io/honua-server:environment:publish-images` with audience
`sts.amazonaws.com`. The `publish-images` environment's deployment policy
admits only `trunk`, `release/*` and the publication tags (`v*.*.*`,
`honua-core-v*`; creating them is limited to repository admins), so the ref
restriction lives in that one GitHub setting. A job without the environment
presents a ref subject and is refused, so the publish jobs must declare
`environment: publish-images` before this root is applied. Pull requests,
other branches and other repositories are refused; the variable validation
rejects any subject that is not a honua-server `publish-*` environment.

## Permissions

One inline policy, `ecr-publish`: `ecr:GetAuthorizationToken` (account-wide
by AWS design) and push, pull, describe and create on the publication
repositories (`repository_names`, default `honua-server`) in `ecr_region`
(default `us-west-2`). `aws_iam_role_policies_exclusive` and
`aws_iam_role_policy_attachments_exclusive` remove any inline or managed
policy attached outside Terraform on apply; read the plan for removals.

## First apply

The role already exists, created outside Terraform. Import it, then plan and
review the trust and policy changes:

```sh
cp backend.tf.example backend.tf   # set the state bucket
terraform init
terraform import -var oidc_provider_arn=arn:aws:iam::<account>:oidc-provider/token.actions.githubusercontent.com \
  module.oidc.aws_iam_role.github_actions honua-server-gha-ecr-publish
terraform plan -var oidc_provider_arn=arn:aws:iam::<account>:oidc-provider/token.actions.githubusercontent.com
```

In the plan, check the trust and the removal of any policy attached by hand.
The component also sets a 3600-second maximum session and tags, and removes
any description or permissions boundary the role has today.

Apply only after the honua-server publish jobs run in the `publish-images`
environment; earlier, every publish fails at credential setup. Set this root to
`"applied": true` (with the `oidc_provider_arn` var) in `../drift-roots.json`
in the change that records the apply.

## State

Remote, at `bootstrap/aws-ecr-publish/terraform.tfstate` (`backend.tf.example`;
copy it to the gitignored `backend.tf`).

## Tests

`terraform test` renders the trust and the policy with the real provider and
fake credentials; nothing reaches AWS.
