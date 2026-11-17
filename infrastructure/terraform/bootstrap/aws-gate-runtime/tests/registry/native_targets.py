"""Authorization targets fixed by a native handler's API endpoint."""

# Bucket handlers use bucket names, rather than access-point aliases.
# https://docs.aws.amazon.com/AmazonS3/latest/API/API_GetBucketPolicy.html
# https://docs.aws.amazon.com/AmazonS3/latest/API/API_GetBucketCors.html
# https://docs.aws.amazon.com/AmazonS3/latest/API/API_ListObjectsV2.html
BUCKET_TARGETS = {
    "s3:listbucket": "bucket", "s3:getbucketpolicy": "bucket",
    "s3:getbucketcors": "bucket", "s3:getbucketnotification": "bucket",
    "s3:getbucketacl": "bucket", "s3:putobjectacl": "object",
    "s3:deleteobject": "object", "s3:getobject": "object", "s3:getobjectversion": "object",
}


def native_target(spec):
    if spec["type"] == "AWS::S3::Bucket":
        return BUCKET_TARGETS.get(spec["action"].lower())
    # Package locations require a bucket name and object key, not an access point.
    # https://docs.aws.amazon.com/AWSCloudFormation/latest/TemplateReference/aws-properties-lambda-function-code.html
    if spec["type"] == "AWS::Lambda::Function" and spec["action"].lower() in {"s3:getobject", "s3:getobjectversion"}:
        return "object"
    # The native BucketPolicy contract requires the bucket's name.
    # https://docs.aws.amazon.com/AWSCloudFormation/latest/TemplateReference/aws-resource-s3-bucketpolicy.html
    if spec["type"] == "AWS::S3::BucketPolicy" and spec["action"].lower() == "s3:getbucketpolicy":
        return "bucket"
    return None


# ELBv2 native types cannot target classic load balancers or another resource kind.
# Check every supported variant when the concrete ARN is unresolved offline.
# https://docs.aws.amazon.com/service-authorization/latest/reference/list_elbv2.html
ELBV2_TARGETS = {
    "LoadBalancer": ("loadbalancer/", {
        "createloadbalancer", "deleteloadbalancer", "modifyloadbalancerattributes",
        "modifycapacityreservation", "setsecuritygroups", "setsubnets", "setipaddresstype",
    }),
    "Listener": ("listener/", {"modifylistener", "modifylistenerattributes", "deletelistener"}),
    "ListenerRule": ("listener-rule/", {"modifyrule", "setrulepriorities", "deleterule"}),
    "TargetGroup": ("targetgroup", set()),
}


def native_variants(spec, service):
    if not spec["type"].startswith("AWS::ElasticLoadBalancingV2::"):
        return None
    target = ELBV2_TARGETS.get(spec["type"].split("::")[-1])
    prefix, action = spec["action"].lower().split(":", 1)
    if target is None or prefix != "elasticloadbalancing":
        return None
    resource_prefix, actions = target
    if action not in actions | {"addtags", "removetags"}:
        return None
    api = next((item for item in service["Actions"] if item["Name"].lower() == action), None)
    if api is None:
        return None
    names = [item["Name"] for item in api.get("Resources", [])
             if item["Name"].startswith(resource_prefix)]
    if not names:
        raise ValueError("Unmapped native ELBv2 authorization: " + spec["action"])
    return names
