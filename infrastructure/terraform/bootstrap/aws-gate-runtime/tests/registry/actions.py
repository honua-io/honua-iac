"""Translate documented S3 API names in Registry schemas into IAM actions.

Source: https://docs.aws.amazon.com/AmazonS3/latest/userguide/using-with-s3-policy-actions.html
Unrecognized actions remain unchanged so absent authorization metadata fails closed.
"""
ALIASES = {
    "s3:PutBucketReplication": "s3:PutReplicationConfiguration",
    "s3:PutObjectLockConfiguration": "s3:PutBucketObjectLockConfiguration",
    "s3:DeleteBucketAnalyticsConfiguration": "s3:PutAnalyticsConfiguration",
    "s3:DeleteBucketCors": "s3:PutBucketCORS",
    "s3:DeleteBucketMetricsConfiguration": "s3:PutMetricsConfiguration",
    "s3:DeleteBucketEncryption": "s3:PutEncryptionConfiguration",
    "s3:DeleteBucketLifecycle": "s3:PutLifecycleConfiguration",
    "s3:DeleteBucketReplication": "s3:PutReplicationConfiguration",
    "s3:DeleteBucketTagging": "s3:PutBucketTagging",
}


def authorization_action(action):
    return ALIASES.get(action, action)


def authorization_actions(action):
    # The CloudFront API authorizes creation and tagging as separate IAM actions.
    # https://docs.aws.amazon.com/cloudfront/latest/APIReference/API_CreateDistributionWithTags.html
    if action == "cloudfront:CreateDistributionWithTags":
        return ["cloudfront:CreateDistribution", "cloudfront:TagResource"]
    return [authorization_action(action)]
