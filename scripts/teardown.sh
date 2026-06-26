#!/usr/bin/env bash
set -euo pipefail

# EKS-FAIL-DEMO teardown.
# Stops any running FIS experiments, deletes k8s workloads (so EBS volumes
# are released cleanly), then deletes the parent stack and the template
# bucket.
#
# Usage:
#   ./scripts/teardown.sh [region] [stack-name]

REGION="${1:-us-east-1}"
STACK="${2:-devops-agent-demo}"
ACCOUNT="$(aws sts get-caller-identity --query Account --output text)"
BUCKET="${STACK}-templates-${ACCOUNT}-${REGION}"

echo "==> Stack: $STACK  Region: $REGION"

CLUSTER="$(aws cloudformation describe-stacks --region "$REGION" --stack-name "$STACK" \
  --query "Stacks[0].Outputs[?OutputKey=='ClusterName'].OutputValue" --output text 2>/dev/null || true)"

echo "==> Stopping any running FIS experiments"
RUNNING="$(aws fis list-experiments --region "$REGION" \
  --query "experiments[?state.status=='running'].id" --output text || true)"
for id in $RUNNING; do
  echo "    stopping $id"
  aws fis stop-experiment --region "$REGION" --id "$id" >/dev/null || true
done

if [[ -n "$CLUSTER" ]]; then
  echo "==> Deleting workload (releases EBS PVs cleanly)"
  aws eks update-kubeconfig --region "$REGION" --name "$CLUSTER" >/dev/null 2>&1 || true
  kubectl delete -f "$(dirname "$0")/../workload/loadgen.yaml" --ignore-not-found || true
  kubectl delete -f "$(dirname "$0")/../workload/pod-killer.yaml" --ignore-not-found || true
  kubectl delete statefulset postgres --ignore-not-found --wait=true || true
  kubectl delete pvc -l app=postgres --ignore-not-found --wait=true || true
  kubectl delete -f "$(dirname "$0")/../workload/" --ignore-not-found || true
fi

echo "==> Cleaning up tag-named NAT/IGW/EIP that may not belong to the stack"
# These resources may have been created imperatively (e.g. by an older
# version of deploy.sh that ran before NAT was in vpc.yaml). Stack delete
# won't touch them, so we sweep by Name tag here.
NAT_ID=$(aws ec2 describe-nat-gateways --region "$REGION" \
  --filter "Name=tag:Name,Values=${STACK}-nat" \
           "Name=state,Values=available,pending" \
  --query 'NatGateways[0].NatGatewayId' --output text 2>/dev/null || echo "None")
if [[ "$NAT_ID" != "None" && -n "$NAT_ID" ]]; then
  echo "    deleting NAT $NAT_ID"
  aws ec2 delete-nat-gateway --region "$REGION" --nat-gateway-id "$NAT_ID" >/dev/null || true
  echo "    waiting for NAT delete..."
  aws ec2 wait nat-gateway-deleted --region "$REGION" --nat-gateway-ids "$NAT_ID" || true
fi
EIP_ALLOC=$(aws ec2 describe-addresses --region "$REGION" \
  --filters "Name=tag:Name,Values=${STACK}-nat-eip" \
  --query 'Addresses[0].AllocationId' --output text 2>/dev/null || echo "None")
if [[ "$EIP_ALLOC" != "None" && -n "$EIP_ALLOC" ]]; then
  echo "    releasing EIP $EIP_ALLOC"
  aws ec2 release-address --region "$REGION" --allocation-id "$EIP_ALLOC" || true
fi

echo "==> Deleting parent stack (waits for completion)"
aws cloudformation delete-stack --region "$REGION" --stack-name "$STACK"
aws cloudformation wait stack-delete-complete --region "$REGION" --stack-name "$STACK" || {
  echo "WARN: stack deletion did not complete cleanly. Check the console."
  exit 1
}

echo "==> Sweeping any leftover IGW/public subnet/public RT named for this stack"
# These also only matter for VPCs created before NAT was in vpc.yaml.
for IGW in $(aws ec2 describe-internet-gateways --region "$REGION" \
    --filters "Name=tag:Name,Values=${STACK}-igw" \
    --query 'InternetGateways[].InternetGatewayId' --output text); do
  for VPC in $(aws ec2 describe-internet-gateways --region "$REGION" \
      --internet-gateway-ids "$IGW" \
      --query 'InternetGateways[].Attachments[].VpcId' --output text); do
    aws ec2 detach-internet-gateway --region "$REGION" --internet-gateway-id "$IGW" --vpc-id "$VPC" || true
  done
  aws ec2 delete-internet-gateway --region "$REGION" --internet-gateway-id "$IGW" || true
done
for SN in $(aws ec2 describe-subnets --region "$REGION" \
    --filters "Name=tag:Name,Values=${STACK}-public-a" \
    --query 'Subnets[].SubnetId' --output text); do
  aws ec2 delete-subnet --region "$REGION" --subnet-id "$SN" || true
done
for RT in $(aws ec2 describe-route-tables --region "$REGION" \
    --filters "Name=tag:Name,Values=${STACK}-public-rt" \
    --query 'RouteTables[].RouteTableId' --output text); do
  aws ec2 delete-route-table --region "$REGION" --route-table-id "$RT" || true
done

echo "==> Sweeping any orphaned EBS volumes tagged for this cluster"
if [[ -n "$CLUSTER" ]]; then
  ORPHAN=$(aws ec2 describe-volumes --region "$REGION" \
    --filters "Name=tag:ebs.csi.aws.com/cluster,Values=$CLUSTER" "Name=status,Values=available" \
    --query 'Volumes[].VolumeId' --output text)
  for v in $ORPHAN; do
    echo "    deleting orphan volume $v"
    aws ec2 delete-volume --region "$REGION" --volume-id "$v" || true
  done
fi

echo "==> Emptying and deleting template bucket s3://${BUCKET}"
aws s3 rm "s3://${BUCKET}" --recursive --region "$REGION" >/dev/null 2>&1 || true
# Purge versioned objects too
aws s3api delete-objects --bucket "$BUCKET" --region "$REGION" \
  --delete "$(aws s3api list-object-versions --bucket "$BUCKET" --region "$REGION" \
    --query '{Objects: Versions[].{Key:Key,VersionId:VersionId}}' 2>/dev/null)" \
  >/dev/null 2>&1 || true
aws s3api delete-bucket --bucket "$BUCKET" --region "$REGION" 2>/dev/null || true

echo "==> Done."
