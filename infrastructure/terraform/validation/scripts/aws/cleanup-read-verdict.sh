#!/usr/bin/env bash
# Read-only resource-fate observations. 0=authoritatively settled, 1=live or
# unsupported resource kind, 3=unverified. No mutating API is reachable here.
cleanup_resource_settled() {
  local reader="$1" region="$2" arn="$3" service operation payload verdict
  local -a args
  case "$arn" in
    arn:aws:ec2:*:elastic-ip/eipalloc-*) service=ec2; operation=describe-addresses; args=(--allocation-ids "${arn##*/}") ;;
    arn:aws:kms:*) service=kms; operation=describe-key; args=(--key-id "$arn") ;;
    arn:aws:secretsmanager:*) service=secretsmanager; operation=describe-secret; args=(--secret-id "$arn") ;;
    arn:aws:ecs:*:cluster/*) service=ecs; operation=describe-clusters; args=(--clusters "$arn") ;;
    arn:aws:ecs:*:service/*/*) service=ecs; operation=describe-services; args=(--cluster "${arn%/*}"); args=(--cluster "${args[1]#*:service/}" --services "$arn") ;;
    arn:aws:ecs:*:task-definition/*) service=ecs; operation=describe-task-definition; args=(--task-definition "$arn") ;;
    arn:aws:batch:*:job-definition/*) service=batch; operation=describe-job-definitions; args=(--job-definitions "$arn") ;;
    arn:aws:acm:*:certificate/*) service=acm; operation=describe-certificate; args=(--certificate-arn "$arn") ;;
    arn:aws:s3:::*/*) return 1 ;;
    arn:aws:s3:::?*) service=s3api; operation=get-bucket-location; args=(--bucket "${arn#arn:aws:s3:::}") ;;
    *) return 1 ;;
  esac
  if ! payload="$("$reader" "$service" "$operation" --region "$region" "${args[@]}" --output json 2>&1)"; then
    # AWS CLI 2.17.61 errorhandler.FilteredExceptionHandler surrounds the
    # ClientError with a newline. Trim framing whitespace only, never warnings
    # or other error text: github.com/aws/aws-cli/blob/2.17.61/awscli/errorhandler.py
    payload="${payload#"${payload%%[![:space:]]*}"}"
    payload="${payload%"${payload##*[![:space:]]}"}"
    [[ "$payload" != *$'\n'* && "$payload" != *$'\r'* ]] || return 3
    # Only the service's authoritative not-found code for this operation is
    # absence. Denial, throttling, transport errors and arbitrary text are not.
    if [[ "$service" == kms && "$payload" =~ ^An\ error\ occurred\ \(NotFoundException\)\ when\ calling\ the\ DescribeKey\ operation: ]] ||
       [[ "$service" == secretsmanager && "$payload" =~ ^An\ error\ occurred\ \(ResourceNotFoundException\)\ when\ calling\ the\ DescribeSecret\ operation: ]] ||
       [[ "$service" == ec2 && "$payload" =~ ^An\ error\ occurred\ \(InvalidAllocationID\.NotFound\)\ when\ calling\ the\ DescribeAddresses\ operation: ]] ||
       [[ "$service" == acm && "$payload" =~ ^An\ error\ occurred\ \(ResourceNotFoundException\)\ when\ calling\ the\ DescribeCertificate\ operation: ]] ||
       [[ "$service" == s3api && "$payload" =~ ^An\ error\ occurred\ \(NoSuchBucket\)\ when\ calling\ the\ GetBucketLocation\ operation: ]]; then
      return 0
    fi
    return 3
  fi
  if ! payload="$(jq -ce -s 'if length==1 and (.[0]|type)=="object" then .[0] else error("unverified response") end' <<<"$payload" 2>/dev/null)"; then return 3; fi
  if ! verdict="$(jq -er --arg arn "$arn" --arg service "$service" --arg operation "$operation" '
    def refuse: error("unverified cleanup response");
    def state($value; $known; $settled):
      if ($value|type)!="string" or ($known|index($value))==null then refuse
      elif ($settled|index($value))!=null then "settled" else "live" end;
    if type!="object" then refuse
    elif $service=="ec2" then
      if (.Addresses|type)!="array" or (has("NextToken") and .NextToken!="") then refuse
      elif (.Addresses|length)==0 then "settled"
      elif (.Addresses|length)==1 and .Addresses[0].AllocationId==($arn|split("/")|last) then "live"
      else refuse end
    elif $service=="kms" then
      if .KeyMetadata.Arn!=$arn then refuse else
      state(.KeyMetadata.KeyState; ["Creating","Enabled","Disabled","PendingDeletion","PendingImport","PendingReplicaDeletion","Unavailable","Updating"]; ["PendingDeletion","PendingReplicaDeletion"]) end
    elif $service=="secretsmanager" then
      if .ARN!=$arn then refuse
      elif .DeletedDate==null then "live"
      elif ((.DeletedDate|type)=="number" and .DeletedDate>0) or
           ((.DeletedDate|type)=="string" and (.DeletedDate|test("^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}(\\.[0-9]+)?(Z|[+-][0-9]{2}:[0-9]{2})$"))) then "settled" else refuse end
    elif $service=="batch" then
      # A deregistered revision stays listed as INACTIVE; an unknown one is an empty list.
      if (.jobDefinitions|type)!="array" or (has("nextToken") and .nextToken!=null and .nextToken!="") then refuse
      elif (.jobDefinitions|length)==0 then "settled"
      elif (.jobDefinitions|length)==1 and .jobDefinitions[0].jobDefinitionArn==$arn then
        state(.jobDefinitions[0].status; ["ACTIVE","INACTIVE"]; ["INACTIVE"])
      else refuse end
    elif $service=="acm" then
      # ACM has no deleted state: a described certificate exists.
      if .Certificate.CertificateArn!=$arn then refuse else "live" end
    elif $service=="s3api" then
      # us-east-1 buckets answer a null LocationConstraint.
      if has("LocationConstraint") and ((.LocationConstraint|type)=="null" or (.LocationConstraint|type)=="string") then "live" else refuse end
    elif $operation=="describe-task-definition" then
      if .taskDefinition.taskDefinitionArn!=$arn then refuse else
      state(.taskDefinition.status; ["ACTIVE","INACTIVE","DELETE_IN_PROGRESS"]; ["INACTIVE"]) end
    else
      (if $operation=="describe-clusters" then .clusters else .services end) as $resources |
      (if $operation=="describe-clusters" then "clusterArn" else "serviceArn" end) as $identity |
      if ($resources|type)!="array" or (.failures|type)!="array" then refuse
      elif ($resources|length)==0 and (.failures|length)==1 and .failures[0].arn==$arn and .failures[0].reason=="MISSING" then "settled"
      elif ($resources|length)==1 and (.failures|length)==0 and $resources[0][$identity]==$arn then
        state($resources[0].status; ["ACTIVE","PROVISIONING","DEPROVISIONING","FAILED","INACTIVE","DRAINING"]; ["INACTIVE"])
      else refuse end
    end' <<<"$payload" 2>/dev/null)"; then return 3; fi
  [[ "$verdict" == settled ]] && return 0
  [[ "$verdict" == live ]] && return 1
  return 3
}

cleanup_validate_tag_response() {
  jq -ser '
    if length!=1 then error("unverified response count") else .[0] end |
    if type!="object" or (.ResourceTagMappingList|type)!="array" or
      (has("PaginationToken") and .PaginationToken!="") or
      any(.ResourceTagMappingList[]; type!="object" or (.ResourceARN|type)!="string" or (.ResourceARN|test("^arn:aws:[A-Za-z0-9-]+:[^[:space:]]+$")|not) or
        (has("Tags") and ((.Tags|type)!="array" or
          any(.Tags[]; type!="object" or (.Key|type)!="string" or (.Value|type)!="string") or
          ((.Tags|map(.Key)|unique|length)!=(.Tags|length)))))
    then error("unverified tag enumeration")
    else [.ResourceTagMappingList[].ResourceARN] end' <<<"$1" 2>/dev/null
}

cleanup_tagged_arns() {
  local reader="$1" payload; shift
  if ! payload="$("$reader" resourcegroupstaggingapi get-resources "$@" --output json 2>/dev/null)"; then return 3; fi
  local arns
  if ! arns="$(cleanup_validate_tag_response "$payload")"; then return 3; fi
  jq -r '.[]' <<<"$arns"
}
