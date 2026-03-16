# Sourced by validation.sh after common globals,
# logging helpers, and shared post-apply validation helpers are defined.

existing_db_security_group_ids() {
  local group_ids

  group_ids="$(run_aws rds describe-db-instances \
    --query "DBInstances[?Endpoint.Address=='${EXISTING_DB_ENDPOINT}'].VpcSecurityGroups[].VpcSecurityGroupId" \
    --output text)"

  if [[ -z "$group_ids" || "$group_ids" == "None" ]]; then
    log_error "Could not resolve RDS security groups for reused DB endpoint $EXISTING_DB_ENDPOINT"
    return 1
  fi

  printf '%s\n' "$group_ids" | tr '\t' '\n' | sed '/^$/d'
}

security_group_allows_db_cidr() {
  local group_id="$1"
  local cidr="$2"
  local cidrs

  cidrs="$(run_aws ec2 describe-security-groups \
    --group-ids "$group_id" \
    --query "SecurityGroups[0].IpPermissions[?IpProtocol=='tcp' && FromPort==\`5432\` && ToPort==\`5432\`].IpRanges[].CidrIp" \
    --output text)"

  if [[ -z "$cidrs" || "$cidrs" == "None" ]]; then
    return 1
  fi

  printf '%s\n' "$cidrs" | tr '\t' '\n' | grep -Fxq "$cidr"
}

authorize_existing_db_runner_ingress() {
  local group_id=""

  if ! has_existing_data_inputs; then
    return 0
  fi

  if [[ -z "$DB_INGRESS_CIDR" ]]; then
    log_error "Runner DB ingress CIDR was empty while reusing AWS data"
    return 1
  fi

  while IFS= read -r group_id; do
    [[ -z "$group_id" ]] && continue

    if security_group_allows_db_cidr "$group_id" "$DB_INGRESS_CIDR"; then
      log_info "Reused RDS security group $group_id already allows $DB_INGRESS_CIDR"
      continue
    fi

    run_aws ec2 authorize-security-group-ingress \
      --group-id "$group_id" \
      --ip-permissions "[{\"IpProtocol\":\"tcp\",\"FromPort\":5432,\"ToPort\":5432,\"IpRanges\":[{\"CidrIp\":\"$DB_INGRESS_CIDR\",\"Description\":\"Honua validation runner ${VALIDATION_RUN_ID}\"}]}]" >/dev/null
    EXISTING_DB_RUNNER_INGRESS_GROUP_IDS+=("$group_id")
    log_info "Authorized temporary RDS ingress from $DB_INGRESS_CIDR on security group $group_id"
  done < <(existing_db_security_group_ids)
}

revoke_existing_db_runner_ingress() {
  local group_id=""

  if [[ "${#EXISTING_DB_RUNNER_INGRESS_GROUP_IDS[@]}" -eq 0 ]]; then
    return 0
  fi

  for group_id in "${EXISTING_DB_RUNNER_INGRESS_GROUP_IDS[@]}"; do
    if ! run_aws ec2 revoke-security-group-ingress \
      --group-id "$group_id" \
      --ip-permissions "[{\"IpProtocol\":\"tcp\",\"FromPort\":5432,\"ToPort\":5432,\"IpRanges\":[{\"CidrIp\":\"$DB_INGRESS_CIDR\"}]}]" >/dev/null 2>&1; then
      log_warn "Failed to revoke temporary RDS ingress from $DB_INGRESS_CIDR on security group $group_id"
      return 1
    fi
    log_info "Revoked temporary RDS ingress from $DB_INGRESS_CIDR on security group $group_id"
  done
}

validate_existing_resource_inputs() {
  local any_existing
  any_existing=false

  if [[ -n "$EXISTING_DB_ENDPOINT" || -n "$EXISTING_DB_CONNECTION_STRING" || -n "$EXISTING_REDIS_CONNECTION_STRING" || -n "$EXISTING_VPC_ID" || -n "$EXISTING_VPC_CIDR" || -n "$EXISTING_PUBLIC_SUBNET_IDS" || -n "$EXISTING_PRIVATE_SUBNET_IDS" ]]; then
    any_existing=true
  fi

  if [[ -n "$EXISTING_DB_ENDPOINT" && -z "$EXISTING_DB_CONNECTION_STRING" ]]; then
    log_error "--existing-db-connection is required when --existing-db-endpoint is provided"
    exit 1
  fi

  if [[ -z "$EXISTING_DB_ENDPOINT" && -n "$EXISTING_DB_CONNECTION_STRING" ]]; then
    log_error "--existing-db-endpoint is required when --existing-db-connection is provided"
    exit 1
  fi

  if [[ "$any_existing" == "true" ]]; then
    if [[ -z "$EXISTING_DB_ENDPOINT" || -z "$EXISTING_DB_CONNECTION_STRING" || -z "$EXISTING_REDIS_CONNECTION_STRING" || -z "$EXISTING_VPC_ID" || -z "$EXISTING_VPC_CIDR" || -z "$EXISTING_PUBLIC_SUBNET_IDS" || -z "$EXISTING_PRIVATE_SUBNET_IDS" ]]; then
      log_error "When reusing AWS data, all values are required: DB endpoint/connection, Redis connection, VPC ID/CIDR, and public/private subnet lists"
      exit 1
    fi
  fi
}

has_existing_data_inputs() {
  [[ -n "$EXISTING_DB_ENDPOINT" &&
    -n "$EXISTING_DB_CONNECTION_STRING" &&
    -n "$EXISTING_REDIS_CONNECTION_STRING" &&
    -n "$EXISTING_VPC_ID" &&
    -n "$EXISTING_VPC_CIDR" &&
    -n "$EXISTING_PUBLIC_SUBNET_IDS" &&
    -n "$EXISTING_PRIVATE_SUBNET_IDS" ]]
}

json_array_items() {
  local raw="$1"
  local csv
  local item

  csv="$(printf '%s' "$raw" | tr -d '[]\"[:space:]')"
  [[ -z "$csv" ]] && return 0

  IFS=',' read -r -a _json_array_items <<< "$csv"
  for item in "${_json_array_items[@]}"; do
    [[ -n "$item" ]] && printf '%s\n' "$item"
  done
}

route_table_id_for_subnet() {
  local subnet_id="$1"
  local route_table_id=""
  local subnet_vpc_id=""
  local attempt

  for attempt in $(seq 1 3); do
    route_table_id="$(run_aws ec2 describe-route-tables \
      --filters "Name=association.subnet-id,Values=$subnet_id" \
      --query 'RouteTables[0].RouteTableId' \
      --output text 2>/dev/null || true)"

    if [[ -n "$route_table_id" && "$route_table_id" != "None" && "$route_table_id" != "null" ]]; then
      printf '%s' "$route_table_id"
      return 0
    fi

    subnet_vpc_id="$(run_aws ec2 describe-subnets \
      --subnet-ids "$subnet_id" \
      --query 'Subnets[0].VpcId' \
      --output text 2>/dev/null || true)"

    if [[ -n "$subnet_vpc_id" && "$subnet_vpc_id" != "None" && "$subnet_vpc_id" != "null" ]]; then
      route_table_id="$(run_aws ec2 describe-route-tables \
        --filters "Name=vpc-id,Values=$subnet_vpc_id" "Name=association.main,Values=true" \
        --query 'RouteTables[0].RouteTableId' \
        --output text 2>/dev/null || true)"

      if [[ -n "$route_table_id" && "$route_table_id" != "None" && "$route_table_id" != "null" ]]; then
        printf '%s' "$route_table_id"
        return 0
      fi
    fi

    sleep 2
  done

  return 1
}

route_table_default_route_target() {
  local route_table_id="$1"
  run_aws ec2 describe-route-tables \
    --route-table-ids "$route_table_id" \
    --query 'RouteTables[0].Routes[?DestinationCidrBlock==`0.0.0.0/0`][0].[NatGatewayId,GatewayId,TransitGatewayId,InstanceId,NetworkInterfaceId]' \
    --output text 2>/dev/null || true
}

subnet_has_igw_default_route() {
  local subnet_id="$1"
  local gateway_id
  local route_table_id

  route_table_id="$(route_table_id_for_subnet "$subnet_id")"
  if [[ -z "$route_table_id" || "$route_table_id" == "None" || "$route_table_id" == "null" ]]; then
    return 1
  fi

  gateway_id="$(run_aws ec2 describe-route-tables \
    --route-table-ids "$route_table_id" \
    --query 'RouteTables[0].Routes[?DestinationCidrBlock==`0.0.0.0/0`].GatewayId | [0]' \
    --output text 2>/dev/null || true)"

  [[ "$gateway_id" == igw-* ]]
}

select_reuse_public_nat_subnet() {
  local subnet_id

  while IFS= read -r subnet_id; do
    [[ -z "$subnet_id" ]] && continue
    if subnet_has_igw_default_route "$subnet_id"; then
      printf '%s' "$subnet_id"
      return 0
    fi
  done < <(json_array_items "$EXISTING_PUBLIC_SUBNET_IDS")

  return 1
}

find_existing_reuse_nat_gateway() {
  run_aws ec2 describe-nat-gateways \
    --filter "Name=vpc-id,Values=$EXISTING_VPC_ID" "Name=state,Values=available,pending" \
    --query 'NatGateways[0].NatGatewayId' \
    --output text 2>/dev/null || true
}

wait_for_nat_gateway_available() {
  local nat_gateway_id="$1"
  local nat_state=""
  local attempt

  for attempt in $(seq 1 60); do
    nat_state="$(run_aws ec2 describe-nat-gateways \
      --nat-gateway-ids "$nat_gateway_id" \
      --query 'NatGateways[0].State' \
      --output text 2>/dev/null || true)"

    case "$nat_state" in
      available)
        return 0
        ;;
      failed|deleted|deleting)
        log_error "NAT gateway $nat_gateway_id entered terminal state '$nat_state'"
        return 1
        ;;
    esac

    sleep 10
  done

  log_error "Timed out waiting for NAT gateway $nat_gateway_id to become available"
  return 1
}

create_reuse_nat_gateway() {
  local public_subnet_id="$1"
  local eip_allocation_id=""
  local nat_gateway_id=""

  eip_allocation_id="$(run_aws ec2 allocate-address --domain vpc --query 'AllocationId' --output text)"
  run_aws ec2 create-tags \
    --resources "$eip_allocation_id" \
    --tags \
      "Key=Name,Value=${NAME_PREFIX_BASE}-${ENVIRONMENT}-reuse-nat-eip" \
      "Key=Owner,Value=terraform-validation" \
      "Key=ValidationRunId,Value=$VALIDATION_RUN_ID" >/dev/null

  nat_gateway_id="$(run_aws ec2 create-nat-gateway \
    --subnet-id "$public_subnet_id" \
    --allocation-id "$eip_allocation_id" \
    --query 'NatGateway.NatGatewayId' \
    --output text)"

  run_aws ec2 create-tags \
    --resources "$nat_gateway_id" \
    --tags \
      "Key=Name,Value=${NAME_PREFIX_BASE}-${ENVIRONMENT}-reuse-nat" \
      "Key=Owner,Value=terraform-validation" \
      "Key=ValidationRunId,Value=$VALIDATION_RUN_ID" >/dev/null

  wait_for_nat_gateway_available "$nat_gateway_id"
  printf '%s' "$nat_gateway_id"
}

ensure_existing_vpc_private_egress() {
  local public_nat_subnet=""
  local nat_gateway_id=""
  local private_subnet_id=""
  local route_table_id=""
  local default_route_target=""
  local updated_route_tables=0
  declare -A route_tables_needing_nat=()

  validate_boolean_value "HONUA_AWS_AUTO_REPAIR_VPC_EGRESS" "$AUTO_REPAIR_VPC_EGRESS"

  if [[ "$AUTO_REPAIR_VPC_EGRESS" != "true" ]]; then
    return 0
  fi

  if ! has_existing_data_inputs; then
    return 0
  fi

  while IFS= read -r private_subnet_id; do
    [[ -z "$private_subnet_id" ]] && continue

    route_table_id="$(route_table_id_for_subnet "$private_subnet_id")"
    if [[ -z "$route_table_id" || "$route_table_id" == "None" ]]; then
      log_error "Could not resolve route table for reused private subnet $private_subnet_id"
      return 1
    fi

    default_route_target="$(route_table_default_route_target "$route_table_id")"
    if [[ -z "$default_route_target" || "$default_route_target" == "None" ]]; then
      route_tables_needing_nat["$route_table_id"]=1
    fi
  done < <(json_array_items "$EXISTING_PRIVATE_SUBNET_IDS")

  if (( ${#route_tables_needing_nat[@]} == 0 )); then
    return 0
  fi

  log_warn "Reused AWS private subnets in $EXISTING_VPC_ID lack outbound egress; repairing VPC for runtime access"

  nat_gateway_id="$(find_existing_reuse_nat_gateway)"
  if [[ -z "$nat_gateway_id" || "$nat_gateway_id" == "None" ]]; then
    if ! public_nat_subnet="$(select_reuse_public_nat_subnet)"; then
      log_error "Could not find a reused public subnet with an internet gateway route in $EXISTING_VPC_ID"
      return 1
    fi

    nat_gateway_id="$(create_reuse_nat_gateway "$public_nat_subnet")"
    log_info "Provisioned reuse NAT gateway $nat_gateway_id in public subnet $public_nat_subnet"
  else
    wait_for_nat_gateway_available "$nat_gateway_id"
    log_info "Reusing existing NAT gateway $nat_gateway_id for $EXISTING_VPC_ID"
  fi

  for route_table_id in "${!route_tables_needing_nat[@]}"; do
    if ! run_aws ec2 create-route \
      --route-table-id "$route_table_id" \
      --destination-cidr-block 0.0.0.0/0 \
      --nat-gateway-id "$nat_gateway_id" >/dev/null 2>&1; then
      run_aws ec2 replace-route \
        --route-table-id "$route_table_id" \
        --destination-cidr-block 0.0.0.0/0 \
        --nat-gateway-id "$nat_gateway_id" >/dev/null
    fi
    updated_route_tables=$((updated_route_tables + 1))
  done

  log_info "Ensured outbound egress for $updated_route_tables reused private route table(s) via NAT gateway $nat_gateway_id"
}
