"""Conditional schema permissions, tied to properties rather than action allowlists.

Schemas describe a resource type's complete feature set. Absent optional property
paths cannot activate those features. Intrinsics remain conservative: unknown
values count as present, and both Fn::If branches are inspected.
"""

# type suffix, action patterns, activating property paths. Empty paths are not
# exceptions: an unclassified action must still pass IAM evaluation.
OPTIONAL = [
    ("ApplicationAutoScaling::ScalableTarget", ["lambda:*ProvisionedConcurrencyConfig"], ["ServiceNamespace=lambda"]),
    ("Batch::ComputeEnvironment", ["eks:*"], ["EksConfiguration"]),
    ("Batch::ComputeEnvironment", ["ec2:DescribeLaunchTemplateVersions"], ["ComputeResources.LaunchTemplate"]),
    ("Budgets::Budget", ["billing:GetBillingViewData"], ["Budget.BillingViewArn"]),
    ("CertificateManager::Certificate", ["acm-pca:*"], ["CertificateAuthorityArn"]),
    ("CloudFront::Distribution", ["cloudfront:CreateConnectionGroup"], ["DistributionConfig.ConnectionMode"]),
    ("CloudTrail::Trail", ["organizations:*"], ["IsOrganizationTrail=True"]),
    ("Cognito::UserPool", ["cognito-idp:AddCustomAttributes"], ["Schema"]),
    ("EC2::FlowLog", ["s3:GetBucketPolicy"], ["LogDestinationType=s3"]),
    ("EC2::EIP", ["ec2:AcceptAddressTransfer"], ["TransferAddress"]),
    ("EC2::FlowLog", ["networkmanager:GetCoreNetwork"], ["ResourceType=CoreNetwork"]),
    ("EC2::VPC", ["ec2:CreateVpcEncryptionControl"], ["VpcEncryptionControl"]),
    ("EC2::VPCEndpoint", ["vpc-lattice:*"], ["ServiceNetworkArn", "VpcEndpointType=ServiceNetwork"]),
    ("EC2::VPCEndpoint", ["vpce:AllowMultiRegion"], ["ServiceRegion"]),
    ("EC2::VPCGatewayAttachment", ["ec2:*VpnGateway"], ["VpnGatewayId"]),
    ("EC2::VPCGatewayAttachment", ["ec2:*InternetGateway"], ["InternetGatewayId"]),
    ("IAM::Policy", ["iam:*UserPolicy"], ["Users"]),
    ("IAM::Policy", ["iam:*GroupPolicy"], ["Groups"]),
    ("Lambda::Function", ["s3:GetObject*"], ["Code.S3Bucket"]),
    ("Lambda::Function", ["elasticfilesystem:*", "s3files:*"], ["FileSystemConfigs"]),
    ("Lambda::Function", ["lambda:GetLayerVersion"], ["Layers"]),
    # Audit-findings destinations belong to the optional data protection policy.
    # https://docs.aws.amazon.com/AWSCloudFormation/latest/TemplateReference/aws-resource-logs-loggroup.html
    ("Logs::LogGroup", ["s3:REST.PUT.OBJECT", "firehose:TagDeliveryStream"], ["DataProtectionPolicy"]),
    ("Logs::LogGroup", ["logs:PutResourcePolicy", "logs:DeleteResourcePolicy"], ["ResourcePolicyDocument"]),
    ("Logs::LogGroup", ["logs:PutIndexPolicy", "logs:DeleteIndexPolicy"], ["FieldIndexPolicies"]),
    ("RDS::DBInstance", ["rds:CreateDBInstanceReadReplica"], ["SourceDBInstanceIdentifier"]),
    ("Route53::HealthCheck", ["route53-recovery-control-config:*"], ["HealthCheckConfig.RoutingControlArn"]),
    ("S3::Bucket", ["s3tables:*"], ["MetadataConfiguration", "MetadataTableConfiguration"]),
    ("S3::Bucket", ["s3:PutBucketDefaultStorageClass"], ["DefaultStorageClass"]),
    ("WAFv2::LoggingConfiguration", ["firehose:ListDeliveryStreams"], ["LogDestinationConfigs~firehose"]),
    ("WAFv2::LoggingConfiguration", ["s3:GetBucketPolicy", "iam:DescribeOrganization"], ["LogDestinationConfigs~s3"]),
]


def property_present(value, path):
    """Unknown intrinsics activate a path; literal missing/empty values do not."""
    if isinstance(value, dict) and "Fn::If" in value:
        return any(property_present(branch, path) for branch in value["Fn::If"][1:])
    if isinstance(value, dict) and any(k.startswith("Fn::") or k == "Ref" for k in value):
        return value != {"Ref": "AWS::NoValue"}
    if not path:
        return value not in (None, [], {}, "")
    name, *rest = path
    return isinstance(value, dict) and name in value and property_present(value[name], rest)


def matches_value(value, path, expected):
    if isinstance(value, dict) and "Fn::If" in value:
        return any(matches_value(branch, path, expected) for branch in value["Fn::If"][1:])
    if isinstance(value, dict) and any(k.startswith("Fn::") or k == "Ref" for k in value):
        return value != {"Ref": "AWS::NoValue"}
    if path:
        name, *rest = path
        return isinstance(value, dict) and name in value and matches_value(value[name], rest, expected)
    return value is not None and str(value) == expected


def arn_service(value):
    """Read a literal ARN service while ignoring substitutions in other fields."""
    import re
    if isinstance(value, dict) and "Fn::Sub" in value:
        value = value["Fn::Sub"]
        if isinstance(value, list):
            value = value[0]
    if not isinstance(value, str):
        return None
    match = re.match(r"^arn:(?:\$\{[^}]+\}|[^:]+):([a-z0-9-]+):", value)
    return match.group(1) if match else None


def destination_matches(value, service):
    if isinstance(value, list):
        return any(destination_matches(item, service) for item in value)
    if isinstance(value, dict) and "Fn::If" in value:
        return any(destination_matches(item, service) for item in value["Fn::If"][1:])
    if value == {"Ref": "AWS::NoValue"} or value in (None, ""):
        return False
    actual = arn_service(value)
    return actual is None or actual == service


def activates(properties, expression):
    if "=" in expression:
        path, expected = expression.split("=", 1)
        return matches_value(properties, path.split("."), expected)
    if "~" in expression:
        path, expected = expression.split("~", 1)
        value = properties.get(path)
        return destination_matches(value, expected)
    return property_present(properties, expression.split("."))


def excluded(resource, action):
    import fnmatch
    for suffix, patterns, paths in OPTIONAL:
        if resource["Type"] == "AWS::" + suffix and any(
            fnmatch.fnmatchcase(action.lower(), pattern.lower()) for pattern in patterns
        ) and not any(activates(resource.get("Properties", {}), path) for path in paths):
            return "Optional feature absent: " + ", ".join(paths)
    return None
