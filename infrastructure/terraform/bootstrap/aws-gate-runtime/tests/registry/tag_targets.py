"""Tag APIs select the resource explicitly named or typed in the request.

https://docs.aws.amazon.com/AmazonCloudWatch/latest/APIReference/API_TagResource.html
https://docs.aws.amazon.com/AmazonCloudWatchLogs/latest/APIReference/API_TagResource.html
https://docs.aws.amazon.com/lambda/latest/api/API_TagResource.html
"""
from requests import request_for

TARGETS = {
    'AWS::CloudWatch::Alarm': ('cloudwatch', 'alarm', 'TagResource', 'UntagResource', 'ListTagsForResource'),
    'AWS::CloudWatch::CompositeAlarm': ('cloudwatch', 'alarm', 'TagResource', 'UntagResource', 'ListTagsForResource'),
    'AWS::Logs::LogGroup': ('logs', 'log-group', 'TagResource', 'UntagResource', 'ListTagsForResource'),
    'AWS::Lambda::Function': ('lambda', 'function', 'TagResource', 'UntagResource', 'ListTags'),
    'AWS::SSM::Parameter': ('ssm', 'parameter', 'AddTagsToResource', 'RemoveTagsFromResource', 'ListTagsForResource'),
    'AWS::S3::Bucket': ('s3', 'bucket', 'TagResource', 'UntagResource', 'ListTagsForResource'),
    'AWS::CloudTrail::Trail': ('cloudtrail', 'trail', 'AddTags', 'RemoveTags', 'ListTags'),
    'AWS::GuardDuty::Detector': ('guardduty', 'detector', 'TagResource', 'UntagResource', 'ListTagsForResource'),
    'AWS::Route53::HealthCheck': ('route53', 'healthcheck', 'ChangeTagsForResource', 'ListTagsForResource'),
    'AWS::Budgets::Budget': ('budgets', 'budget', 'TagResource', 'UntagResource', 'ListTagsForResource'),
    'AWS::RDS::DBInstance': ('rds', 'db', 'AddTagsToResource', 'RemoveTagsFromResource', 'ListTagsForResource'),
    'AWS::RDS::DBParameterGroup': ('rds', 'pg', 'AddTagsToResource', 'RemoveTagsFromResource', 'ListTagsForResource'),
    'AWS::RDS::DBSubnetGroup': ('rds', 'subgrp', 'AddTagsToResource', 'RemoveTagsFromResource', 'ListTagsForResource'),
    'AWS::CloudFront::VpcOrigin': ('cloudfront', 'vpcorigin', 'TagResource', 'UntagResource', 'ListTagsForResource'),
    'AWS::CloudFront::Function': ('cloudfront', 'function', 'TagResource', 'UntagResource', 'ListTagsForResource'),
    'AWS::CloudFront::Distribution': ('cloudfront', 'distribution', 'TagResource', 'UntagResource', 'ListTagsForResource'),
    'AWS::ECS::Cluster': ('ecs', 'cluster', 'TagResource', 'UntagResource', 'ListTagsForResource'),
    'AWS::ECS::Service': ('ecs', 'service', 'TagResource', 'UntagResource', 'ListTagsForResource'),
    'AWS::ECS::TaskDefinition': ('ecs', 'task-definition', 'TagResource', 'UntagResource', 'ListTagsForResource'),
    'AWS::Batch::ComputeEnvironment': ('batch', 'compute-environment', 'TagResource', 'UntagResource'),
    'AWS::Batch::JobDefinition': ('batch', 'job-definition-revision', 'TagResource', 'UntagResource'),
    'AWS::Batch::JobQueue': ('batch', 'job-queue', 'TagResource', 'UntagResource'),
    'AWS::WAFv2::WebACL': ('wafv2', 'webacl', 'TagResource', 'UntagResource', 'ListTagsForResource'),
    'AWS::Backup::BackupPlan': ('backup', 'backupPlan', 'TagResource', 'UntagResource', 'ListTags'),
    'AWS::Backup::BackupVault': ('backup', 'backupVault', 'TagResource', 'UntagResource', 'ListTags'),
}


def tag_target(spec):
    target = TARGETS.get(spec['type'])
    if target is None:
        return None
    service, name, *actions = target
    prefix, action = spec['action'].lower().split(':', 1)
    if prefix == service and action in {a.lower() for a in actions}:
        return name
    return None


def first_tag(spec):
    return spec['handler'] == 'create' and spec['action'].lower().split(':')[1] in {
        'tagresource', 'addtagstoresource', 'addtags', 'changetagsforresource',
    }


# A CloudFormation resource handler tags the ID of the resource it manages.
# https://docs.aws.amazon.com/AWSEC2/latest/APIReference/API_CreateTags.html
EC2_TARGETS = {
    'AWS::EC2::VPCEndpoint': ('vpc-endpoint', 'CreateVpcEndpoint'),
    'AWS::EC2::SecurityGroup': ('security-group', 'CreateSecurityGroup'),
    'AWS::EC2::Subnet': ('subnet', 'CreateSubnet'),
    'AWS::EC2::RouteTable': ('route-table', 'CreateRouteTable'),
    'AWS::EC2::EIP': ('elastic-ip', 'AllocateAddress'),
    'AWS::EC2::NatGateway': ('natgateway', 'CreateNatGateway'),
    'AWS::EC2::InternetGateway': ('internet-gateway', 'CreateInternetGateway'),
    'AWS::EC2::VPC': ('vpc', 'CreateVpc'),
    'AWS::EC2::FlowLog': ('vpc-flow-log', 'CreateFlowLogs'),
}


def ec2_tag_requests(spec, service):
    target = EC2_TARGETS.get(spec['type'])
    if target is None or spec['action'].lower() not in {'ec2:createtags', 'ec2:deletetags'}:
        return None
    name, creation = target
    spec = {**spec, 'resource_name': name}
    requests = [request_for(spec, service)]
    if spec['handler'] == 'create' and spec['action'].lower() == 'ec2:createtags':
        action, arn, context = requests[0]
        # Both provider paths must pass; a standalone first-tag call lacks CreateAction.
        requests.append((action, arn, {**context, 'ec2:CreateAction': creation}))
    return requests
