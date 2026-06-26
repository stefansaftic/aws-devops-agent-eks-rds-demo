#!/usr/bin/env bash
# Simulate RDS connection exhaustion by setting max_connections to 1.
# DevOps Agent should trace: API errors -> "too many connections" in pod logs -> RDS parameter.
set -euo pipefail

REGION="${1:-us-east-1}"
STACK_NAME="${2:-devops-agent-demo}"

DB_INSTANCE=$(aws cloudformation describe-stacks \
  --stack-name "${STACK_NAME}" \
  --region "${REGION}" \
  --query "Stacks[0].Outputs[?OutputKey=='RdsInstanceId'].OutputValue" \
  --output text)

PARAM_GROUP="${STACK_NAME}-api-db-params-break"

echo "==> Creating restrictive parameter group..."
aws rds create-db-parameter-group \
  --db-parameter-group-name "${PARAM_GROUP}" \
  --db-parameter-group-family postgres16 \
  --description "Demo: max_connections=1 to simulate exhaustion" \
  --region "${REGION}" 2>/dev/null || true

aws rds modify-db-parameter-group \
  --db-parameter-group-name "${PARAM_GROUP}" \
  --parameters "ParameterName=max_connections,ParameterValue=1,ApplyMethod=immediate" \
  --region "${REGION}"

echo "==> Applying to RDS instance (requires reboot)..."
aws rds modify-db-instance \
  --db-instance-identifier "${DB_INSTANCE}" \
  --db-parameter-group-name "${PARAM_GROUP}" \
  --apply-immediately \
  --region "${REGION}"

echo "==> Rebooting instance to apply parameter change..."
aws rds reboot-db-instance \
  --db-instance-identifier "${DB_INSTANCE}" \
  --region "${REGION}"

echo ""
echo "🔥 RDS max_connections set to 1. Instance is rebooting (~2-3 min)."
echo "   After reboot, only 1 connection will be allowed -> API pods will fail."
echo ""
echo "To restore:"
echo "  ./scripts/rds-fix-connections.sh ${REGION} ${STACK_NAME}"
