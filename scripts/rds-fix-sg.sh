#!/usr/bin/env bash
# Restore RDS security group ingress after rds-break-sg.sh
set -euo pipefail

REGION="${1:-us-east-1}"
STACK_NAME="${2:-devops-agent-demo}"

echo "==> Fetching RDS Security Group ID..."
RDS_SG=$(aws cloudformation describe-stacks \
  --stack-name "${STACK_NAME}" \
  --region "${REGION}" \
  --query "Stacks[0].Outputs[?OutputKey=='RdsSecurityGroupId'].OutputValue" \
  --output text)

VPC_CIDR=$(aws cloudformation describe-stacks \
  --stack-name "${STACK_NAME}" \
  --region "${REGION}" \
  --query "Stacks[0].Outputs[?OutputKey=='VpcCidr'].OutputValue" \
  --output text 2>/dev/null || echo "10.0.0.0/16")

echo "==> Re-adding ingress on SG: ${RDS_SG} (port 5432 from ${VPC_CIDR})"
aws ec2 authorize-security-group-ingress \
  --group-id "${RDS_SG}" \
  --protocol tcp \
  --port 5432 \
  --cidr "${VPC_CIDR}" \
  --region "${REGION}" 2>/dev/null || echo "(rule may already exist)"

echo ""
echo "✅ RDS Security Group ingress RESTORED."
echo "   API pods should recover within ~15 seconds."
