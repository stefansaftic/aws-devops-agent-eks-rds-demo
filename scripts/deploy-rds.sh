#!/usr/bin/env bash
# Deploy the API app after RDS is available.
# Run this AFTER deploy.sh has completed and the RDS stack is up.
set -euo pipefail

REGION="${1:-us-east-1}"
STACK_NAME="${2:-devops-agent-demo}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WORKLOAD_DIR="${SCRIPT_DIR}/../workload"

echo "==> Fetching RDS endpoint from CloudFormation..."
RDS_ENDPOINT=$(aws cloudformation describe-stacks \
  --stack-name "${STACK_NAME}" \
  --region "${REGION}" \
  --query "Stacks[0].Outputs[?OutputKey=='RdsEndpoint'].OutputValue" \
  --output text)

if [[ -z "$RDS_ENDPOINT" || "$RDS_ENDPOINT" == "None" ]]; then
  echo "ERROR: RDS endpoint not found. Is the stack deployed with RDS?"
  exit 1
fi

echo "==> RDS Endpoint: ${RDS_ENDPOINT}"

# python:3.12-slim is pulled through the regional ECR pull-through cache,
# the same way deploy.sh handles other manifests.
ACCOUNT="$(aws sts get-caller-identity --query Account --output text)"
ECR_PREFIX="${ACCOUNT}.dkr.ecr.${REGION}.amazonaws.com/ecr-public"

echo "==> Applying API namespace and resources..."
sed -e "s|PLACEHOLDER_RDS_ENDPOINT|${RDS_ENDPOINT}|g" \
    -e "s|__ECR_PREFIX__|${ECR_PREFIX}|g" \
    "${WORKLOAD_DIR}/api-app.yaml" | kubectl apply -f -

echo "==> Waiting for API pods to be ready..."
kubectl rollout status deployment/api-server -n api-demo --timeout=180s

echo "==> Applying API load generator..."
kubectl apply -f "${WORKLOAD_DIR}/api-loadgen.yaml"

echo ""
echo "API app deployed. Load generator running."
echo "   RDS Endpoint: ${RDS_ENDPOINT}"
echo ""
echo "Test:"
echo "  kubectl port-forward svc/api-server -n api-demo 8080:80"
echo "  curl http://localhost:8080/health"
echo "  curl http://localhost:8080/query"
echo "  curl http://localhost:8080/write"
