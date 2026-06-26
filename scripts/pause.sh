#!/usr/bin/env bash
set -euo pipefail

# Pause the demo to minimize cost.
# Scales the managed node group to 0 (no EC2 charges). Cluster control
# plane and VPC endpoints stay up.
#
# Usage: ./scripts/pause.sh [region] [stack-name]

REGION="${1:-us-east-1}"
STACK="${2:-devops-agent-demo}"

CLUSTER="$(aws cloudformation describe-stacks --region "$REGION" --stack-name "$STACK" \
  --query "Stacks[0].Outputs[?OutputKey=='ClusterName'].OutputValue" --output text)"

NG="$(aws eks list-nodegroups --region "$REGION" --cluster-name "$CLUSTER" \
  --query 'nodegroups[0]' --output text)"

echo "==> Scaling node group $NG to 0"
aws eks update-nodegroup-config --region "$REGION" \
  --cluster-name "$CLUSTER" --nodegroup-name "$NG" \
  --scaling-config minSize=0,maxSize=6,desiredSize=0 >/dev/null

echo "==> Waiting for nodes to terminate"
aws eks wait nodegroup-active --region "$REGION" \
  --cluster-name "$CLUSTER" --nodegroup-name "$NG"

echo "==> Paused. Run ./scripts/resume.sh to bring it back."
