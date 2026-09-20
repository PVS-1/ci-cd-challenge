#!/usr/bin/env bash
set -Eeuo pipefail

# OBJECTIVE 1: create Elastic Beanstalk application and environment.
# Standalone Bash script. It does not call any other local file.

REGION="eu-west-1"
APPLICATION_NAME="cmtr-msdta2zd-app"
ENVIRONMENT_NAME="cmtr-msdta2zd-env"
SERVICE_ROLE_NAME="ElasticBeanstalkServiceRole"
INSTANCE_PROFILE_NAME="ElasticBeanstalkInstanceProfileRole"
VPC_NAME="cmtr-msdta2zd-vpc"
VPC_CIDR="10.0.0.0/16"

TEMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TEMP_DIR"' EXIT

if [[ -z "${PLATFORM_ARN:-}" ]]; then
  PLATFORM_ARN="$(aws elasticbeanstalk list-platform-versions \
    --region "$REGION" \
    --filters Type=PlatformName,Operator=Contains,Values=Python \
    --max-items 100 \
    --query 'reverse(sort_by(PlatformSummaryList,&PlatformVersion))[0].PlatformArn' \
    --output text)"
fi

if [[ -z "$PLATFORM_ARN" || "$PLATFORM_ARN" == "None" ]]; then
  printf '%s\n' 'Could not find a Python Elastic Beanstalk platform.' >&2
  exit 1
fi

printf 'Using Python platform: %s\n' "$PLATFORM_ARN"

printf '%s\n' '=== 1. Verify AWS identity ==='
aws sts get-caller-identity \
  --query '{Account:Account,Arn:Arn}' \
  --output json

cat > "$TEMP_DIR/elasticbeanstalk-trust.json" <<'JSON'
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Principal": {"Service": "elasticbeanstalk.amazonaws.com"},
      "Action": "sts:AssumeRole"
    }
  ]
}
JSON

cat > "$TEMP_DIR/ec2-trust.json" <<'JSON'
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Principal": {"Service": "ec2.amazonaws.com"},
      "Action": "sts:AssumeRole"
    }
  ]
}
JSON

ensure_managed_policy() {
  local role_name="$1"
  local policy_arn="$2"
  local attached_policies

  attached_policies="$(aws iam list-attached-role-policies \
    --role-name "$role_name" \
    --query 'AttachedPolicies[].PolicyArn' \
    --output text)"

  if printf '%s\n' "$attached_policies" | grep -Fq -- "$policy_arn"; then
    printf 'Policy already attached: %s\n' "$policy_arn"
  else
    aws iam attach-role-policy \
      --role-name "$role_name" \
      --policy-arn "$policy_arn"
  fi
}

printf '%s\n' '=== 2. Create or verify Elastic Beanstalk service role ==='
if aws iam get-role --role-name "$SERVICE_ROLE_NAME" >/dev/null 2>&1; then
  printf 'Already exists: %s\n' "$SERVICE_ROLE_NAME"
else
  aws iam create-role \
    --role-name "$SERVICE_ROLE_NAME" \
    --assume-role-policy-document "file://$TEMP_DIR/elasticbeanstalk-trust.json"
fi
ensure_managed_policy \
  "$SERVICE_ROLE_NAME" \
  "arn:aws:iam::aws:policy/service-role/AWSElasticBeanstalkEnhancedHealth"

printf '%s\n' '=== 3. Create or verify EC2 instance profile role ==='
if aws iam get-role --role-name "$INSTANCE_PROFILE_NAME" >/dev/null 2>&1; then
  printf 'Already exists: %s\n' "$INSTANCE_PROFILE_NAME"
else
  aws iam create-role \
    --role-name "$INSTANCE_PROFILE_NAME" \
    --assume-role-policy-document "file://$TEMP_DIR/ec2-trust.json"
fi
ensure_managed_policy \
  "$INSTANCE_PROFILE_NAME" \
  "arn:aws:iam::aws:policy/AWSElasticBeanstalkWebTier"

if aws iam get-instance-profile \
  --instance-profile-name "$INSTANCE_PROFILE_NAME" >/dev/null 2>&1; then
  printf 'Instance profile already exists: %s\n' "$INSTANCE_PROFILE_NAME"
else
  aws iam create-instance-profile \
    --instance-profile-name "$INSTANCE_PROFILE_NAME"
fi

profile_roles="$(aws iam get-instance-profile \
  --instance-profile-name "$INSTANCE_PROFILE_NAME" \
  --query 'InstanceProfile.Roles[].RoleName' \
  --output text)"

if ! printf '%s\n' "$profile_roles" | tr '\t' '\n' | grep -Fqx -- "$INSTANCE_PROFILE_NAME"; then
  aws iam add-role-to-instance-profile \
    --instance-profile-name "$INSTANCE_PROFILE_NAME" \
    --role-name "$INSTANCE_PROFILE_NAME"
else
  printf 'Role already attached: %s\n' "$INSTANCE_PROFILE_NAME"
fi

printf '%s\n' '=== 4. Create or verify public VPC networking ==='
VPC_ID="$(aws ec2 describe-vpcs \
  --filters "Name=tag:Name,Values=$VPC_NAME" \
  --region "$REGION" \
  --query 'Vpcs[0].VpcId' \
  --output text)"

if [[ -z "$VPC_ID" || "$VPC_ID" == "None" ]]; then
  VPC_ID="$(aws ec2 create-vpc \
    --cidr-block "$VPC_CIDR" \
    --region "$REGION" \
    --query 'Vpc.VpcId' \
    --output text)"
  aws ec2 create-tags --resources "$VPC_ID" --tags "Key=Name,Value=$VPC_NAME" --region "$REGION"
  aws ec2 modify-vpc-attribute --vpc-id "$VPC_ID" --enable-dns-support Value=true --region "$REGION"
  aws ec2 modify-vpc-attribute --vpc-id "$VPC_ID" --enable-dns-hostnames Value=true --region "$REGION"
else
  printf 'Already exists: VPC %s\n' "$VPC_ID"
fi

INTERNET_GATEWAY_ID="$(aws ec2 describe-internet-gateways \
  --filters "Name=attachment.vpc-id,Values=$VPC_ID" \
  --region "$REGION" \
  --query 'InternetGateways[0].InternetGatewayId' \
  --output text)"

if [[ -z "$INTERNET_GATEWAY_ID" || "$INTERNET_GATEWAY_ID" == "None" ]]; then
  INTERNET_GATEWAY_ID="$(aws ec2 create-internet-gateway \
    --region "$REGION" \
    --query 'InternetGateway.InternetGatewayId' \
    --output text)"
  aws ec2 create-tags --resources "$INTERNET_GATEWAY_ID" --tags "Key=Name,Value=$VPC_NAME-igw" --region "$REGION"
  aws ec2 attach-internet-gateway \
    --internet-gateway-id "$INTERNET_GATEWAY_ID" \
    --vpc-id "$VPC_ID" \
    --region "$REGION"
fi

ROUTE_TABLE_ID="$(aws ec2 describe-route-tables \
  --filters "Name=vpc-id,Values=$VPC_ID" "Name=tag:Name,Values=$VPC_NAME-public-routes" \
  --region "$REGION" \
  --query 'RouteTables[0].RouteTableId' \
  --output text)"

if [[ -z "$ROUTE_TABLE_ID" || "$ROUTE_TABLE_ID" == "None" ]]; then
  ROUTE_TABLE_ID="$(aws ec2 create-route-table \
    --vpc-id "$VPC_ID" \
    --region "$REGION" \
    --query 'RouteTable.RouteTableId' \
    --output text)"
  aws ec2 create-tags --resources "$ROUTE_TABLE_ID" --tags "Key=Name,Value=$VPC_NAME-public-routes" --region "$REGION"
fi

DEFAULT_ROUTE_GATEWAY="$(aws ec2 describe-route-tables \
  --route-table-ids "$ROUTE_TABLE_ID" \
  --region "$REGION" \
  --query "RouteTables[0].Routes[?DestinationCidrBlock=='0.0.0.0/0'].GatewayId | [0]" \
  --output text)"

if [[ -z "$DEFAULT_ROUTE_GATEWAY" || "$DEFAULT_ROUTE_GATEWAY" == "None" ]]; then
  aws ec2 create-route \
    --route-table-id "$ROUTE_TABLE_ID" \
    --destination-cidr-block 0.0.0.0/0 \
    --gateway-id "$INTERNET_GATEWAY_ID" \
    --region "$REGION"
fi

read -r -a AVAILABILITY_ZONES <<< "$(aws ec2 describe-availability-zones \
  --filters Name=state,Values=available \
  --region "$REGION" \
  --query 'AvailabilityZones[].ZoneName' \
  --output text)"

if (( ${#AVAILABILITY_ZONES[@]} < 2 )); then
  printf '%s\n' 'At least two availability zones are required for Elastic Beanstalk.' >&2
  exit 1
fi

SUBNET_IDS=()
SUBNET_NAMES=("$VPC_NAME-public-1" "$VPC_NAME-public-2")
SUBNET_CIDRS=("10.0.1.0/24" "10.0.2.0/24")

for index in 0 1; do
  subnet_name="${SUBNET_NAMES[$index]}"
  subnet_cidr="${SUBNET_CIDRS[$index]}"
  subnet_zone="${AVAILABILITY_ZONES[$index]}"

  subnet_id="$(aws ec2 describe-subnets \
    --filters "Name=vpc-id,Values=$VPC_ID" "Name=tag:Name,Values=$subnet_name" \
    --region "$REGION" \
    --query 'Subnets[0].SubnetId' \
    --output text)"

  if [[ -z "$subnet_id" || "$subnet_id" == "None" ]]; then
    subnet_id="$(aws ec2 describe-subnets \
      --filters "Name=vpc-id,Values=$VPC_ID" "Name=cidr-block,Values=$subnet_cidr" \
      --region "$REGION" \
      --query 'Subnets[0].SubnetId' \
      --output text)"

    if [[ -n "$subnet_id" && "$subnet_id" != "None" ]]; then
      aws ec2 create-tags \
        --resources "$subnet_id" \
        --tags "Key=Name,Value=$subnet_name" \
        --region "$REGION"
      printf 'Using existing subnet %s for CIDR %s\n' "$subnet_id" "$subnet_cidr"
    fi
  fi

  if [[ -z "$subnet_id" || "$subnet_id" == "None" ]]; then
    subnet_id="$(aws ec2 create-subnet \
      --vpc-id "$VPC_ID" \
      --cidr-block "$subnet_cidr" \
      --availability-zone "$subnet_zone" \
      --region "$REGION" \
      --query 'Subnet.SubnetId' \
      --output text)"
    aws ec2 create-tags --resources "$subnet_id" --tags "Key=Name,Value=$subnet_name" --region "$REGION"
    aws ec2 modify-subnet-attribute --subnet-id "$subnet_id" --map-public-ip-on-launch Value=true --region "$REGION"
  fi

  association_id="$(aws ec2 describe-route-tables \
    --filters "Name=vpc-id,Values=$VPC_ID" \
    --region "$REGION" \
    --query "RouteTables[].Associations[?SubnetId=='$subnet_id'].RouteTableAssociationId | [0]" \
    --output text)"

  if [[ -z "$association_id" || "$association_id" == "None" ]]; then
    aws ec2 associate-route-table \
      --route-table-id "$ROUTE_TABLE_ID" \
      --subnet-id "$subnet_id" \
      --region "$REGION"
  fi

  SUBNET_IDS+=("$subnet_id")
done

printf '%s\n' '=== 5. Create application if missing ==='
APPLICATION_EXISTS="$(aws elasticbeanstalk describe-applications \
  --application-names "$APPLICATION_NAME" \
  --region "$REGION" \
  --query 'Applications[0].ApplicationName' \
  --output text)"

if [[ "$APPLICATION_EXISTS" != "$APPLICATION_NAME" ]]; then
  aws elasticbeanstalk create-application \
    --application-name "$APPLICATION_NAME" \
    --description 'Elastic Beanstalk Flask CI-CD application' \
    --region "$REGION"
else
  printf 'Already exists: %s\n' "$APPLICATION_NAME"
fi

printf '%s\n' '=== 6. Create environment if missing ==='
ENVIRONMENT_STATUS="$(aws elasticbeanstalk describe-environments \
  --application-name "$APPLICATION_NAME" \
  --environment-names "$ENVIRONMENT_NAME" \
  --region "$REGION" \
  --query 'Environments[0].Status' \
  --output text)"

if [[ "$ENVIRONMENT_STATUS" == "Terminating" ]]; then
  printf 'Environment is still terminating. Wait and rerun.\n' >&2
  exit 1
fi

if [[ "$ENVIRONMENT_STATUS" == "Terminated" || -z "$ENVIRONMENT_STATUS" || "$ENVIRONMENT_STATUS" == "None" ]]; then
  cat > "$TEMP_DIR/environment-options.json" <<JSON
[
  {"Namespace":"aws:elasticbeanstalk:environment","OptionName":"ServiceRole","Value":"$SERVICE_ROLE_NAME"},
  {"Namespace":"aws:autoscaling:launchconfiguration","OptionName":"IamInstanceProfile","Value":"$INSTANCE_PROFILE_NAME"},
  {"Namespace":"aws:ec2:vpc","OptionName":"VPCId","Value":"$VPC_ID"},
  {"Namespace":"aws:ec2:vpc","OptionName":"Subnets","Value":"${SUBNET_IDS[0]},${SUBNET_IDS[1]}"},
  {"Namespace":"aws:ec2:vpc","OptionName":"ELBSubnets","Value":"${SUBNET_IDS[0]},${SUBNET_IDS[1]}"},
  {"Namespace":"aws:ec2:vpc","OptionName":"ELBScheme","Value":"public"},
  {"Namespace":"aws:ec2:vpc","OptionName":"AssociatePublicIpAddress","Value":"true"}
]
JSON

  aws elasticbeanstalk create-environment \
    --application-name "$APPLICATION_NAME" \
    --environment-name "$ENVIRONMENT_NAME" \
    --platform-arn "$PLATFORM_ARN" \
    --option-settings "file://$TEMP_DIR/environment-options.json" \
    --region "$REGION"
else
  printf 'Environment already exists with status: %s\n' "$ENVIRONMENT_STATUS"
fi

printf '%s\n' '=== 7. Environment status ==='
aws elasticbeanstalk describe-environments \
  --application-name "$APPLICATION_NAME" \
  --environment-names "$ENVIRONMENT_NAME" \
  --region "$REGION" \
  --query 'Environments[].{Name:EnvironmentName,Status:Status,Health:Health,CNAME:CNAME}' \
  --output table
