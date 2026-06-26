#!/usr/bin/env bash
# Simulate RDS connectivity failure by removing the ingress rule on the RDS security group.
# DevOps Agent should trace: API 503 -> pod logs (connection refused/timeout) -> RDS SG has no ingress.
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

echo "==> Revoking ingress on SG: ${RDS_SG} (port 5432 from ${VPC_CIDR})"
aws ec2 revoke-security-group-ingress \
  --group-id "${RDS_SG}" \
  --protocol tcp \
  --port 5432 \
  --cidr "${VPC_CIDR}" \
  --region "${REGION}" 2>/dev/null || echo "(rule may already be removed)"

echo ""
echo "🔥 RDS Security Group ingress REMOVED."
echo "   API pods will start failing /health checks within ~10 seconds."
echo ""
echo "To restore:"
echo "  ./scripts/rds-fix-sg.sh ${REGION} ${STACK_NAME}"
