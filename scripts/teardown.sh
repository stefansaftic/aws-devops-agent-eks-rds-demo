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

echo "==> Deleting parent stack (waits for completion)"
aws cloudformation delete-stack --region "$REGION" --stack-name "$STACK"
aws cloudformation wait stack-delete-complete --region "$REGION" --stack-name "$STACK" || {
  echo "WARN: stack deletion did not complete cleanly. Check the console."
  exit 1
}

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
