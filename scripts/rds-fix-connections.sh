#!/usr/bin/env bash
# Restore RDS to default parameter group after rds-kill-connections.sh
set -euo pipefail

REGION="${1:-us-east-1}"
STACK_NAME="${2:-devops-agent-demo}"

DB_INSTANCE=$(aws cloudformation describe-stacks \
  --stack-name "${STACK_NAME}" \
  --region "${REGION}" \
  --query "Stacks[0].Outputs[?OutputKey=='RdsInstanceId'].OutputValue" \
  --output text)

PARAM_GROUP="${STACK_NAME}-api-db-params-break"

echo "==> Reverting to default parameter group..."
aws rds modify-db-instance \
  --db-instance-identifier "${DB_INSTANCE}" \
  --db-parameter-group-name "default.postgres16" \
  --apply-immediately \
  --region "${REGION}"

echo "==> Rebooting to apply..."
aws rds reboot-db-instance \
  --db-instance-identifier "${DB_INSTANCE}" \
  --region "${REGION}"

echo "==> Cleaning up custom parameter group (will fail until detached, that's ok)..."
sleep 5
aws rds delete-db-parameter-group \
  --db-parameter-group-name "${PARAM_GROUP}" \
  --region "${REGION}" 2>/dev/null || echo "(will clean up after reboot completes)"

echo ""
echo "✅ RDS parameter group reverted to default. Rebooting (~2-3 min)."
