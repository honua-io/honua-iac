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
    return None
